// SPDX-License-Identifier: Apache-2.0
// CXL-specific part of tb/CXL_apb_tb.sv. The link and CXL.io pins pass
// through the wrapper, so the host model of the core TB (tb/CXL_host.svh)
// drives them unchanged: M2S flits with Req, RwD and BIRsp messages, S2M
// flits checked and parsed, CXL.io both ways, all against a reference
// memory. The registers carry the rest: CTRL sets the HDM base and HDM-DB,
// BI sends device back-invalidation requests and BIDONE returns their
// results (checked against the core's own), STATUS is compared with the
// reference's count of lines not Invalid after each phase, and IRQ_STATUS
// with the events the core raised in the phase (each one then seen masked,
// driving the pin, and cleared).
// Covered: HDM-H traffic in three back-pressure modes with a moving base,
// poison, the range edges, every error flit (CRC, type, sequence, unit
// code, odd RwD), Req overflow, every line held (STATUS 16), HDM-DB with
// evictions, device BI requests (legal and illegal BIRsps), a BI write
// while full (BI_OVF) and two completions unread (BIDONE_OVF).
localparam int LINES = 16, RQD = 4, WQD = 2, SFE = 4, IOD = 2;
wire  rst_n = PRESETN;
logic bi_en = 0;
`define CXL_CLK PCLK
`define CXL_C dut.u_core
`define CXL_BI_APB
`include "CXL_host.svh"

// one APB user at a time: the BI thread and the phase checks
bit         apb_lock = 0;
logic [31:0] en_cur = 0;
logic [1:0] bd_q [$];                          // the core's BI results not yet read
always @(negedge PCLK) if (PRESETN && dut.u_core.bi_done) bd_q.push_back(dut.u_core.bi_state);
task automatic lock();
  while (apb_lock) @(negedge PCLK);
  apb_lock = 1;
endtask
task automatic unlock();
  apb_lock = 0;
endtask
task automatic set_ctrl();
  lock();
  wr(A_CTRL, {15'd0, bi_en, hdm_base});
  unlock();
endtask
// pop BIDONE and compare it with the core's result
task automatic get_bidone();
  logic [1:0] e;
  poll(A_FLAGS, 1 << FLAG_BIDONE_AVAIL, 1 << FLAG_BIDONE_AVAIL, 5000);
  rd(A_BIDONE);
  e = bd_q.size() > 0 ? bd_q.pop_front() : 2'bxx;
  if (rdv !== {30'd0, e}) fail($sformatf("BIDONE %h, expected %b", rdv, e));
endtask
// device BI requests through the registers, one at a time
initial forever begin
  @(negedge PCLK);
  if (bi_req_n > 0 && PRESETN && $urandom % 20 == 0) begin
    lock();
    wr(A_BI, {26'd0, 2'($urandom), 4'($urandom)});
    poll(A_FLAGS, 1 << FLAG_BI_FULL, 0, 5000);
    n_bi_acc++; bi_req_n--;
    get_bidone();
    unlock();
  end
end

// after a phase: STATUS, the events seen, then each interrupt bit set is
// seen masked, driving the pin and cleared; a new random enable mask
task automatic phase_end(input string ph);
  int          n;
  logic [31:0] st;
  drain(ph);
  while (apb_lock || bd_q.size() != 0) wait_clk(1);
  lock();
  n = 0;
  for (int l = 0; l < LINES; l++) if (rmt[l] != 2'b00) n++;
  rd_exp(A_STATUS, n);
  rd(A_IRQ_STATUS);
  st = rdv;
  if (st[7:0] !== ev_mask) fail($sformatf("%s: IRQ_STATUS %h, events %b", ph, st, ev_mask));
  if (st != 0) begin
    wr(A_IRQ_ENABLE, 0);
    if (irq !== 1'b0) fail("irq with every interrupt masked");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    cycles(1);
    if (irq !== 1'b1) fail("no irq with an interrupt pending and enabled");
    wr(A_IRQ_STATUS, st);
    rd_exp(A_IRQ_STATUS, 0);
  end
  en_cur = $urandom & IRQ_ALL;
  wr(A_IRQ_ENABLE, en_cur);
  unlock();
endtask
task automatic ptraffic(input int nq, input int nw, input string ph);
  fork
    req_driver(nq);
    rwd_driver(nw);
  join
  phase_end(ph);
endtask

task automatic ip_func;
  ref_clear();
  exp_clear();
  hdm_base = 16'h1230;
  set_ctrl();
  wr(A_IRQ_ENABLE, IRQ_ALL);
  ho_ndr = 2; ho_drs = 2; ho_bis = 1; ho_io = 2;
  wait_clk(3);
  // reads of the reset memory
  p_out = 0;
  for (int l = 0; l < LINES; l++) begin f_off = l; send_req(4'd2); end
  f_off = -100;
  phase_end("reset memory");
  // HDM-H traffic, three back-pressure modes, moving base, CXL.io both ways
  for (int m = 0; m < 3; m++) begin
    tx_mode = m == 2 ? 3 : m;
    io_rx_mode = m;
    h_gap = m == 1 ? 0 : 20;
    h_beat_gap = m == 1 ? 0 : 1;
    p_out = 10;
    for (int i = 0; i < 2; i++) begin hio_flit(); dio_flit(); end
    ptraffic(60, 40, $sformatf("traffic %0d", m));
    hdm_base = m == 0 ? 16'hFFF8 : 16'h5557;
    set_ctrl();
  end
  tx_mode = 0; io_rx_mode = 0; h_gap = 20; h_beat_gap = 1;
  // poison set, read, cleared
  for (int l = 0; l < 2; l++) begin
    f_off = l;
    f_po = 1; send_rwd(4'd1); wait_clk(40);
    send_req(4'd1); wait_clk(40);
    f_po = 0; send_rwd(4'd1); wait_clk(40);
  end
  f_po = -1;
  phase_end("poison");
  // the range edges
  for (int i = 0; i < 2; i++) begin
    f_off = i == 0 ? -1 : LINES;
    send_rwd(4'd1); wait_clk(40);
    send_req(4'd1); wait_clk(40);
  end
  f_off = -100;
  phase_end("range edges");
  // error flits: bad CRC, reserved type, a skipped sequence number, a
  // reserved unit code, an RwD header in a second unit
  for (int e = 1; e <= 5; e++) begin
    h_err = e;
    while (h_err != 0) begin
      if (e >= 3) begin send_req(rnd_req_op()); send_rwd(4'd1); end
      wait_clk(30);
    end
    ptraffic(10, 5, $sformatf("error flit %0d", e));
  end
  // Req messages without credit: the FIFO fills, two are dropped
  tx_mode = 4;
  wait_clk(20);
  h_ovf = 1; f_mf = 3;
  for (int i = 0; i < RQD + 2; i++) begin
    f_off = i % LINES;
    send_req(i >= RQD ? 4'd8 : 4'd0);
  end
  x_ovf += 2; hc_req += 2;
  f_off = -100; f_mf = -1;
  wait_clk(600);
  h_ovf = 0; tx_mode = 0;
  phase_end("Req overflow");
  // every line taken (STATUS reads 16), then given back
  p_out = 0; f_mf = 0;
  for (int l = 0; l < LINES; l++) begin f_off = l; f_mv = 2; send_req(4'd0); end
  phase_end("every line held");
  for (int l = 0; l < LINES; l++) begin f_off = l; f_mv = 0; send_req(4'd10); end
  f_off = -100; f_mf = -1; f_mv = -1;
  phase_end("every line given back");
  // HDM-DB: evictions, device BI requests, illegal BIRsps
  bi_en = 1;
  set_ctrl();
  for (int m = 0; m < 2; m++) begin
    tx_mode = m;
    bi_illegal = m == 1 ? 30 : 0;
    bi_wb = 30;
    p_out = 5;
    bi_req_n = 15;
    ptraffic(80, 40, $sformatf("HDM-DB %0d", m));
  end
  bi_illegal = 0;
  // BISnpCur and BISnpData on lines held Any or Shared: the host's answer
  // leaves them Invalid, Shared or Any
  p_out = 0;
  for (int i = 0; i < 12; i++) begin
    f_off = i % 4; f_mf = 0; f_mv = i % 3 == 0 ? 3 : 2;
    send_req(4'd1);
    phase_end("line taken");
    lock();
    wr(A_BI, {26'd0, 2'(i % 2), 4'(i % 4)});
    poll(A_FLAGS, 1 << FLAG_BI_FULL, 0, 100);
    n_bi_acc++;
    get_bidone();
    rd(A_BIDONE);                              // empty: the last result again
    unlock();
  end
  f_off = -100; f_mf = -1; f_mv = -1; p_out = 5;
  phase_end("BISnpCur and BISnpData");
  // a result captured in the clock BIDONE is popped: one result unread, a
  // BI request on an Invalid line, then the read at each offset
  for (int d = 0; d < 8; d++) begin
    int l;
    l = -1;
    for (int k = 0; k < LINES; k++) if (rmt[k] == 2'b00 && l < 0) l = k;
    lock();
    wr(A_BI, {26'd0, 2'd2, 4'(l)});
    poll(A_FLAGS, 1 << FLAG_BIDONE_AVAIL, 1 << FLAG_BIDONE_AVAIL, 100);
    wr(A_BI, {26'd0, 2'd2, 4'(l)});
    repeat (d) @(negedge PCLK);
    apb_now(0, A_BIDONE, 0, 0);
    cycles(6);
    rd(A_FLAGS);
    if (rdv[FLAG_BIDONE_AVAIL]) rd(A_BIDONE);
    n_bi_acc += 2;
    bd_q.delete();
    unlock();
    phase_end($sformatf("BIDONE pop at offset %0d", d));
  end
  // two BI requests completed at once (lines Invalid), BIDONE unread: the
  // second result is dropped
  begin : b_bidone_ovf
    int l1, l2;
    l1 = -1; l2 = -1;
    for (int l = 0; l < LINES; l++) if (rmt[l] == 2'b00) begin if (l1 < 0) l1 = l; else if (l2 < 0) l2 = l; end
    if (l2 < 0) fail("no two lines Invalid");
    lock();
    for (int i = 0; i < 2; i++) begin
      wr(A_BI, {26'd0, 2'd2, 4'(i == 0 ? l1 : l2)});
      poll(A_FLAGS, 1 << FLAG_BI_FULL, 0, 100);
      n_bi_acc++;
    end
    cycles(4);
    get_bidone();
    if (bd_q.size() != 1) fail($sformatf("%0d BI results pending, expected 1", bd_q.size()));
    bd_q.delete();
    unlock();
  end
  phase_end("BIDONE overflow");
  // a BI request written with HDM-DB off waits; a second write is dropped;
  // HDM-DB on lets the first through
  bi_en = 0;
  set_ctrl();
  lock();
  wr(A_BI, {26'd0, 2'd3, 4'd5});
  wr(A_BI, {26'd0, 2'd0, 4'd6});
  cycles(20);
  rd_exp(A_FLAGS, 1 << FLAG_BI_FULL);
  unlock();
  bi_en = 1;
  set_ctrl();
  lock();
  poll(A_FLAGS, 1 << FLAG_BI_FULL, 0, 100);
  n_bi_acc++;
  get_bidone();
  unlock();
  phase_end("BI while HDM-DB off");
  bi_en = 0;
  set_ctrl();
  tx_mode = 0;
  ptraffic(30, 20, "HDM-H again");
  // left pending for the reset at the end: a BI result
  bi_en = 1;
  set_ctrl();
  lock();
  wr(A_BI, {26'd0, 2'd2, 4'd0});
  cycles(10);
  unlock();
endtask
