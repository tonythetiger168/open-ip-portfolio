// SPDX-License-Identifier: Apache-2.0
// HDMI_RX_DMA-specific part of tb/HDMI_RX_DMA_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; a TMDS source process drives
// tmds_ch0..2. Covered through the registers: HPD, VSYNC / HSYNC decode in
// STATUS, captures at three frame buffer placements checked in memory, LINES,
// CYCLES, DONE, a short line (STATUS.len_err, zero padding), an AXI write
// error (ERR interrupt), irq masking.
`include "apb/tv_apb_common.svh"

initial begin tmds_ch0 = 10'h354; tmds_ch1 = 10'h354; tmds_ch2 = 10'h354; end
int f_disp [3] = '{0, 0, 0};
function automatic logic [9:0] f_enc(input logic [7:0] d, input int c);
  logic [8:0] qm; logic [9:0] q; int n1, n1q, n0q; bit xn;
  n1 = $countones(d);
  xn = (n1 > 4) || (n1 == 4 && d[0] == 1'b0);
  qm[0] = d[0];
  for (int i = 1; i < 8; i++) qm[i] = xn ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
  qm[8] = !xn;
  n1q = $countones(qm[7:0]); n0q = 8 - n1q;
  if (f_disp[c] == 0 || n1q == n0q) begin
    q = {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
    f_disp[c] += qm[8] ? (n1q - n0q) : (n0q - n1q);
  end else if ((f_disp[c] > 0 && n1q > n0q) || (f_disp[c] < 0 && n0q > n1q)) begin
    q = {1'b1, qm[8], ~qm[7:0]};
    f_disp[c] += 2 * int'(qm[8]) + (n0q - n1q);
  end else begin
    q = {1'b0, qm[8], qm[7:0]};
    f_disp[c] += -2 * int'(!qm[8]) + (n1q - n0q);
  end
  return q;
endfunction
task automatic f_ctl(input bit vs, input bit hs, input int n);
  repeat (n) begin
    @(negedge PCLK);
    case ({vs, hs}) 2'b00: tmds_ch0 = 10'h354; 2'b01: tmds_ch0 = 10'h0AB; 2'b10: tmds_ch0 = 10'h154; default: tmds_ch0 = 10'h2AB; endcase
    tmds_ch1 = 10'h354; tmds_ch2 = 10'h354; f_disp = '{0, 0, 0};
  end
endtask
logic [31:0] f_px [$];                                // pixels sent, line by line
// one frame of v lines; line k has lens[k] pixels
task automatic f_frame(input int lens []);
  f_px.delete();
  f_ctl(0, 0, 4); f_ctl(1, 0, 6); f_ctl(0, 0, 8);
  foreach (lens[k]) begin
    f_ctl(0, 1, 4); f_ctl(0, 0, 40);
    for (int i = 0; i < lens[k]; i++) begin
      logic [31:0] p;
      p = {8'h00, 24'($urandom)};
      f_px.push_back(p);
      @(negedge PCLK);
      tmds_ch0 = f_enc(p[7:0], 0); tmds_ch1 = f_enc(p[15:8], 1); tmds_ch2 = f_enc(p[23:16], 2);
    end
  end
  f_ctl(0, 0, 40);
endtask
function automatic logic [31:0] place(input int k);
  return (k == 0) ? 32'h0000_0040 : (k == 1) ? 32'hBFFF_F000 : 32'h8000_0FC0;
endfunction

task automatic ip_func;
  int lens [];
  // hot-plug detect and sync decode
  if (hpd !== 1'b0) fail("hpd high out of reset");
  wr(A_CTRL, 1); cycles(1);
  if (hpd !== 1'b1) fail("hpd does not follow CTRL.hpd_en");
  f_ctl(1, 1, 3);                                     // the token stays on the pins
  rd(A_STATUS);
  if (rdv[5:4] !== 2'b11) fail($sformatf("STATUS vsync / hsync = %b", rdv[5:4]));
  f_ctl(0, 0, 3);
  rd(A_STATUS);
  if (rdv[5:4] !== 2'b00) fail($sformatf("STATUS vsync / hsync = %b after the sync", rdv[5:4]));
  // captures at three placements: 12 x 3
  lens = new[3]; lens = '{12, 12, 12};
  for (int k = 0; k < 3; k++) begin
    logic [31:0] fb;
    fb = place(k);
    wr(A_FB_ADDR, fb); wr(A_GEOM, {16'd12, 16'd64}); wr(A_V_ACTIVE, 3);
    wr(A_CMD, 1);
    rd(A_STATUS);
    if (rdv[0] !== 1'b1) fail("not busy after CMD.arm");
    f_frame(lens);
    poll(A_STATUS, 32'h1, 32'h0, 50);
    for (int l = 0; l < 3; l++) for (int i = 0; i < 12; i++)
      if (mem.peek(fb + 32'(64 * l + 4 * i)) !== f_px[12 * l + i]) begin
        fail($sformatf("placement %0d line %0d pixel %0d", k, l, i)); break;
      end
    rd_exp(A_LINES, 3);
    rd(A_STATUS);
    if (rdv[3:1] !== 3'b000) fail($sformatf("placement %0d: STATUS err / ovf / len_err %b", k, rdv[3:1]));
    rd(A_CYCLES);
    if (rdv == 0) fail("CYCLES 0");
    tv_irq(IRQ_DONE, "capture");
  end
  // a short line: zero padding and STATUS.len_err
  lens = new[2]; lens = '{8, 5};
  wr(A_FB_ADDR, 32'h0001_0000); wr(A_GEOM, {16'd8, 16'd32}); wr(A_V_ACTIVE, 2);
  wr(A_CMD, 1);
  f_frame(lens);
  poll(A_STATUS, 32'h1, 32'h0, 50);
  rd(A_STATUS);
  if (rdv[3] !== 1'b1) fail("no STATUS.len_err on a short line");
  for (int i = 5; i < 8; i++) if (mem.peek(32'h0001_0020 + 32'(4 * i)) !== 0) fail("short line not padded with zeros");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // AXI write error: ERR interrupt
  mem.err_lo = 32'h0002_0000 + 32; mem.err_hi = mem.err_lo + 4;
  lens = new[2]; lens = '{8, 8};
  wr(A_FB_ADDR, 32'h0002_0000); wr(A_GEOM, {16'd8, 16'd32});
  wr(A_CMD, 1);
  f_frame(lens);
  poll(A_STATUS, 32'h1, 32'h0, 50);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI error");
  tv_irq(IRQ_ERR, "AXI error");
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
