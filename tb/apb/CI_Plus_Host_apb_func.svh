// SPDX-License-Identifier: Apache-2.0
// CI_Plus_Host-specific part of tb/CI_Plus_Host_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; the CAM model of
// tb/ci_cam_model.svh sits on the card pins and loops the transport stream.
// Covered through the registers: power-on ignored with no card, DET and
// STATUS.present, power-up (RESET length, READY), CIS read with WAIT#
// cycles, COR write (STATUS.io_mode), interface reset (LAST_ST), a
// host-to-module message, FR taken away once, a TX giving up after FR_MAX
// polls (STATUS.tx_fail), module-to-host messages (RX_LEN, the buffer held
// until CMD.rx_arm, STATUS.rx_ovf), a bus timeout (TS_TO), AXI read and
// write errors (ERR, STATUS.err), IREQ, the transport stream routed and
// bypassed (TS_TO), card removal during a TX, CMD.power_off, irq masking.
// Coverage closure: a 68-byte CIS copy and a 68-byte TX at 0x7FFF_FFFC
// (1 beat, then 16 beats from 0x8000_0000), messages at low addresses
// after them, bytes that set and clear every data bit, an interrupt left
// pending for the reset that follows, FLAGS read; the COR at 0x7FFE (every
// address bit), the CAM's other STATUS bits in LAST_ST.
`include "apb/tv_apb_common.svh"
`define CAM_CLK PCLK
`include "ci_cam_model.svh"
initial begin ts_in_data = 0; ts_in_valid = 0; ts_in_sop = 0; end

logic [7:0]  ci_b [];                              // byte lists
logic [31:0] ci_cis, ci_tx, ci_rx;                 // buffer addresses
function automatic logic [7:0] ci_mbyte(input logic [31:0] a, input int i);
  logic [31:0] w;
  w = mem.peek(a + 32'(4 * (i / 4)));
  return w[8 * (i % 4) +: 8];
endfunction
task automatic ci_timing(input int s, input int st, input int h);
  cam_setup = s; cam_strobe = st;
  wr(A_TIMING, {16'd0, 4'(h), 8'(st), 4'(s)});
endtask
task automatic ci_power(input int rst, input string what);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h2, 32'h2, 2000);
  if (cam_rst_len < rst || cam_rst_len > rst + 1) fail($sformatf("%s: RESET high %0d clocks, RST_CLKS %0d", what, cam_rst_len, rst));
  tv_irq(IRQ_READY, what);
endtask
task automatic ci_cis_rd(input int n, input bit chk, input string what);
  for (int i = 0; i < n + 4; i++) mem.poke(ci_cis + 32'(4 * i), 32'hA5A5_A5A5);
  wr(A_CIS_ADDR, ci_cis); wr(A_CIS_LEN, n);
  wr(A_CMD, 4);
  poll(A_STATUS, 32'h8, 32'h0, 20000);
  if (chk) begin
    for (int i = 0; i < n; i++)
      if (ci_mbyte(ci_cis, i) !== cam_attr[2 * i]) begin
        fail($sformatf("%s: byte %0d = %h, CIS %h", what, i, ci_mbyte(ci_cis, i), cam_attr[2 * i])); break;
      end
    if (mem.peek(ci_cis + 32'(4 * ((n + 3) / 4))) !== 32'hA5A5_A5A5) fail({what, ": written past the end"});
  end
  tv_irq_pin(IRQ_CFG, what);
endtask
task automatic ci_send(input logic [7:0] d [], input bit exp_fail, input bit chk, input string what);
  int m0;
  for (int i = 0; i < d.size(); i += 4) begin
    logic [31:0] w;
    w = 0;
    for (int j = 0; j < 4 && i + j < d.size(); j++) w[8 * j +: 8] = d[i + j];
    mem.poke(ci_tx + 32'(i), w);
  end
  wr(A_TX_ADDR, ci_tx); wr(A_TX_LEN, d.size());
  m0 = cam_in_n.size();
  wr(A_CMD, 32);
  poll(A_STATUS, 32'h8, 32'h0, 50000);
  rd(A_STATUS);
  if (rdv[6] !== exp_fail) fail($sformatf("%s: STATUS.tx_fail %b", what, rdv[6]));
  if (!exp_fail && chk) begin
    if (cam_in_n.size() != m0 + 1) fail({what, ": the CAM got no message"});
    else begin
      int n;
      n = cam_in_n.pop_back();
      if (n != d.size()) fail($sformatf("%s: CAM got %0d bytes of %0d", what, n, d.size()));
      for (int i = n - 1; i >= 0; i--) begin
        logic [7:0] b;
        b = cam_in.pop_back();
        if (b !== d[i]) fail($sformatf("%s: byte %0d = %h, expected %h", what, i, b, d[i]));
      end
    end
  end
  if (!chk) begin cam_in.delete(); cam_in_n.delete(); end
  tv_irq_pin(IRQ_TX_DONE, what);
endtask
task automatic ci_recv(input logic [7:0] d [], input int store, input string what);
  for (int i = 0; i < 24; i++) mem.poke(ci_rx + 32'(4 * i), 32'h5A5A_5A5A);
  wr(A_RX_ADDR, ci_rx);
  cam_send(d);
  poll(A_STATUS, 32'h10, 32'h10, 20000);
  rd_exp(A_RX_LEN, d.size());
  rd(A_STATUS);
  if (rdv[5] !== (d.size() > store)) fail($sformatf("%s: STATUS.rx_ovf %b", what, rdv[5]));
  for (int i = 0; i < store && i < d.size(); i++)
    if (ci_mbyte(ci_rx, i) !== d[i]) begin fail($sformatf("%s: byte %0d = %h, expected %h", what, i, ci_mbyte(ci_rx, i), d[i])); break; end
  if (store < d.size() && mem.peek(ci_rx + 32'(4 * ((store + 3) / 4))) !== 32'h5A5A_5A5A) fail({what, ": stored past RX_MAX"});
  tv_irq(IRQ_RX, what);
endtask
logic [7:0] ci_ts [$];
bit         ci_ts_sop = 0;
always @(posedge PCLK) if (ts_out_valid) begin ci_ts.push_back(ts_out_data); if (ts_out_sop) ci_ts_sop = 1; end
task automatic ci_packet(input int n);
  ci_ts.delete(); ci_ts_sop = 0;
  for (int i = 0; i < n; i++) begin
    @(negedge PCLK);
    ts_in_valid = 1; ts_in_sop = (i == 0); ts_in_data = (i == 0) ? 8'h47 : 8'(i * 13);
  end
  @(negedge PCLK); ts_in_valid = 0; ts_in_sop = 0;
  cycles(4);
endtask

task automatic ip_func;
  for (int i = 0; i < 128; i++) cam_attr[2 * i] = (i % 2) ? 8'(~(i * 37)) : 8'(i * 37);
  ci_cis = 32'h0010_0000; ci_tx = 32'h0020_0000; ci_rx = 32'h0030_0000;
  ci_timing(1, 3, 1);
  wr(A_WAITS, {16'd50, 16'd0}); wr(A_POLL, {16'd0, 16'd20});
  cam_cor_addr = 15'h7FFE;                           // every address bit is used
  wr(A_COR, {9'd0, 8'h0F, 15'h7FFE}); wr(A_RX_MAX, 64);
  // no card: power-on ignored
  wr(A_CTRL, 1);
  wr(A_CMD, 1);
  cycles(10);
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b00 || ci_vcc_en !== 1'b0) fail("powered without a card");
  // insertion, power-up
  cam_cd_n = 0; cycles(4);
  rd(A_STATUS);
  if (rdv[8] !== 1'b1) fail("STATUS.present low with a card");
  tv_irq(IRQ_DET, "card inserted");
  ci_power(50, "power-up");
  // CIS with WAIT# cycles: 10 bytes
  cam_wait = 6;
  ci_cis_rd(10, 1, "CIS read");
  wr(A_IRQ_STATUS, IRQ_ALL);
  cam_wait = 0;
  // COR: I/O mode
  wr(A_CMD, 8);
  poll(A_STATUS, 32'h4, 32'h4, 500);
  if (cam_cor !== 8'h0F || !cam_io) fail("COR not written");
  tv_irq(IRQ_CFG, "COR write");
  // interface reset; the CAM shows its other STATUS bits meanwhile
  cam_rs_dly = 100;
  wr(A_CMD, 16);
  cam_st_x = 6'h3F;
  cycles(30);
  if (cam_fr) fail("FR during the interface reset");
  poll(A_LAST_ST, 32'hFF, 32'h3F, 200);
  cam_st_x = 6'h00;
  poll(A_STATUS, 32'h8, 32'h0, 5000);
  rd(A_LAST_ST);
  if (rdv[6] !== 1'b1) fail("LAST_ST without FR after the interface reset");
  tv_irq(IRQ_CFG, "interface reset");
  // messages to the CAM: setup 0 / hold 0 / strobe 2, then FR taken away once
  ci_timing(0, 2, 0);
  ci_b = new[7]; ci_b = '{8'h9F, 8'h80, 8'h10, 8'h01, 8'h02, 8'h03, 8'h04};
  ci_send(ci_b, 0, 1, "TX");
  wr(A_IRQ_STATUS, IRQ_ALL);
  ci_timing(1, 3, 1);
  cam_steal = 1;
  ci_b = new[9]; ci_b = '{8'h01, 8'hFE, 8'h02, 8'hFD, 8'h04, 8'hFB, 8'h08, 8'hF7, 8'h10};
  ci_send(ci_b, 0, 1, "TX with FR taken away");
  if (cam_steal != 0) fail("FR steal not exercised");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // FR never comes: the TX gives up after FR_MAX polls
  cam_fr_off = 1; wr(A_POLL, {16'd5, 16'd20});
  ci_b = new[3]; ci_b = '{8'h01, 8'h02, 8'h03};
  ci_send(ci_b, 1, 1, "TX without FR");
  wr(A_IRQ_STATUS, IRQ_ALL);
  cam_fr_off = 0; wr(A_POLL, {16'd0, 16'd20});
  rd_exp(A_COUNTS, {16'd0, 16'd2});
  // messages from the CAM
  wr(A_CTRL, 5);
  ci_b = new[9]; ci_b = '{8'h9F, 8'h80, 8'h11, 8'h03, 8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'hEE};
  ci_recv(ci_b, 64, "RX");
  ci_b = new[5]; ci_b = '{8'h20, 8'h40, 8'h80, 8'h7F, 8'hBF};
  cam_send(ci_b);
  cycles(2000);
  tv_no_irq(IRQ_RX, "RX buffer full");
  wr(A_CMD, 64);
  poll(A_STATUS, 32'h10, 32'h10, 20000);
  for (int i = 0; i < 5; i++) if (ci_mbyte(ci_rx, i) !== ci_b[i]) begin fail("second RX message"); break; end
  tv_irq(IRQ_RX, "second RX");
  wr(A_CMD, 64);
  wr(A_RX_MAX, 8);
  ci_b = new[22];
  foreach (ci_b[i]) ci_b[i] = 8'(i * 5 + 1);
  ci_recv(ci_b, 8, "RX over RX_MAX");
  wr(A_RX_MAX, 64);
  wr(A_CTRL, 1);
  wr(A_CMD, 64);
  rd_exp(A_COUNTS, {16'd3, 16'd2});
  // bus timeout: WAIT# longer than WAIT_MAX, bytes read as 0xFF
  cam_wait = 200; wr(A_WAITS, {16'd50, 16'd20});
  mem.poke(ci_cis, 0);
  wr(A_CIS_LEN, 2); wr(A_CMD, 4);
  poll(A_STATUS, 32'h8, 32'h0, 5000);
  if (mem.peek(ci_cis) !== 32'h0000_FFFF) fail($sformatf("timed-out bytes %h", mem.peek(ci_cis)));
  rd(A_TS_TO);
  if (rdv[31:16] !== 16'd2) fail($sformatf("TO_CNT %0d", rdv[31:16]));
  tv_irq_pin(IRQ_BUS_TO, "bus timeout");
  wr(A_IRQ_STATUS, IRQ_ALL);
  cam_wait = 0; wr(A_WAITS, {16'd50, 16'd0});
  // AXI errors: a CIS write and a TX read
  mem.err_lo = ci_cis; mem.err_hi = ci_cis + 4;
  ci_cis_rd(3, 0, "CIS with an AXI error");
  rd(A_STATUS);
  if (rdv[7] !== 1'b1) fail("no STATUS.err after a CIS write error");
  tv_irq(IRQ_ERR, "CIS write error");
  mem.err_lo = ci_tx; mem.err_hi = ci_tx + 4;
  ci_b = new[4]; ci_b = '{8'h01, 8'h02, 8'h03, 8'h04};
  ci_send(ci_b, 0, 0, "TX with an AXI error");
  tv_irq(IRQ_ERR, "TX read error");
  mem.err_lo = '1; mem.err_hi = '1;
  // IREQ
  cam_irq = 1; cycles(10); cam_irq = 0; cycles(5);
  tv_irq(IRQ_IREQ, "IREQ");
  // transport stream through the CAM, then bypassed
  wr(A_CTRL, 3);
  ci_packet(188);
  if (ci_ts.size() != 188 || !ci_ts_sop) fail($sformatf("TS through the CAM: %0d bytes", ci_ts.size()));
  else for (int i = 1; i < 188; i++) if (ci_ts[i] !== ~8'(i * 13)) begin fail($sformatf("TS byte %0d not from the CAM", i)); break; end
  rd_exp(A_TS_TO, {16'd2, 16'd1});
  wr(A_CTRL, 1);
  ci_packet(188);
  if (ci_ts.size() != 188 || ci_ts[5] !== 8'(5 * 13)) fail("TS bypass");
  // address / burst sweep: 68 CIS bytes written and 68 TX bytes read at
  // 0x7FFF_FFFC as 1 beat, then 16 beats from 0x8000_0000 after the 4 KB
  // split, so every AxADDR bit 2..31 and AxLEN bit 0..3 rises and falls;
  // a message at a low address follows
  ci_cis = 32'h7FFF_FFFC;
  ci_cis_rd(68, 1, "sweep CIS");
  wr(A_IRQ_STATUS, IRQ_ALL);
  ci_tx = 32'h7FFF_FFFC;
  ci_b = new[68];
  foreach (ci_b[i]) ci_b[i] = (i % 2) ? 8'(~(i * 29)) : 8'(i * 29);
  ci_send(ci_b, 0, 1, "sweep TX");
  wr(A_IRQ_STATUS, IRQ_ALL);
  ci_tx = 32'h0000_0010;
  ci_b = new[2]; ci_b = '{8'h55, 8'hAA};
  ci_send(ci_b, 0, 1, "low TX");
  wr(A_IRQ_STATUS, IRQ_ALL);
  ci_cis = 32'h0000_0020;
  ci_cis_rd(1, 1, "low CIS");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // card removal during a TX: tx_fail, the DMA flushed
  for (int i = 0; i < 50; i++) mem.poke(ci_tx + 32'(4 * i), $urandom);
  wr(A_TX_LEN, 200); wr(A_CMD, 32);
  cycles(300);
  cam_cd_n = 1;
  poll(A_STATUS, 32'h8, 32'h0, 5000);
  rd(A_STATUS);
  if (rdv[8] !== 1'b0 || rdv[6] !== 1'b1 || rdv[3:0] !== 4'b0000) fail($sformatf("removal during a TX: STATUS %h", rdv));
  tv_irq_pin(IRQ_TX_DONE, "TX ended by the removal");
  tv_irq(IRQ_DET, "card removed");
  // power-off command, then power-up for the reset that follows
  cam_cd_n = 0; cycles(4);
  ci_power(50, "power-up after removal");
  wr(A_CMD, 2);
  cycles(2);
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b00) fail("power-off");
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h2, 32'h2, 2000);
  wr(A_CIS_LEN, 40); wr(A_CMD, 4);                  // still running at the reset
  tv_irq_pin(IRQ_READY, "power-up");                // left pending for the reset
  rd_exp(A_FLAGS, 0);
  cam_cd_n = 1;                                      // no card after the reset (no DET then)
  if (mem.errors != 0 || cam_errors != 0) fail("AXI or card bus rule violations");
endtask
