// SPDX-License-Identifier: Apache-2.0
// LTI-specific part of tb/ARM_Local_Translation_Interface_apb_tb.sv. The TB
// is the LTI manager on the link, LA, LR and LC pins and programs the
// table and invalidations through the registers.
// Covered through the registers: TBL0..TBL2 (every entry written, full-width
// fields), requests answered from the programmed table (OK, translation
// and permission faults, the lowest matching entry, substream entries),
// STATUS (every context tag out), INV (by StreamID and all, one taken while
// tags are out, a second held until the first synchronizes, a third
// dropped), every interrupt bit.
// manager
int          m_cr = 0;                     // credits held
bit          req_on = 0, nocrd = 0, hold = 0, bad_lc = 0;
bit          cap = 0;                      // at most 8 requests and tags outstanding
int          p_req = 60, n_req = 0, n_rsp = 0;
logic [35:0] mq [$];                       // expected: {id, resp, pa, attr}
bit          t_out [0:7];
int          t_due [0:7];
int          now = 0;
int          n_sync = 0;
always @(posedge PCLK) if (PRESETN && dut.u_core.inv_done) n_sync++;
// the table as programmed
bit          e_v [0:7], e_ssv [0:7];
logic [7:0]  e_sid [0:7], e_ss [0:7], e_attr [0:7];
logic [19:0] e_va [0:7], e_pa [0:7];
logic [3:0]  e_pm [0:7];

initial begin
  lm_open_req = 0; lc_valid = 0; lc_ctag = 0;
  {la_valid, la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv} = '0;
  for (int i = 0; i < 8; i++) begin t_out[i] = 0; t_due[i] = 0; e_v[i] = 0; end
end
always @(posedge PCLK) now++;

// expected response of a request on the table as programmed
function automatic logic [35:0] expect_rsp(input logic [3:0] id, input logic [19:0] va, input logic [7:0] sid,
                                           input logic [7:0] ss, input logic ssv, input logic [1:0] rw,
                                           input logic ins, input logic pr);
  for (int i = 0; i < 8; i++)
    if (e_v[i] && e_sid[i] == sid && e_va[i] == va && (!e_ssv[i] || ssv && e_ss[i] == ss)) begin
      if (rw[0] && !e_pm[i][0] || rw[1] && !e_pm[i][1] || ins && !e_pm[i][2] || !pr && !e_pm[i][3])
        return {id, 2'd2, 20'd0, 8'd0};
      return {id, 2'd0, e_pa[i], e_attr[i]};
    end
  return {id, 2'd1, 20'd0, 8'd0};
endfunction

always @(negedge PCLK) begin : b_req
  {la_valid, la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv} = {$urandom, $urandom};
  la_valid = 0;
  if (PRESETN && la_credit) m_cr++;
  if (PRESETN && nocrd) begin
    nocrd = 0; la_valid = 1;
  end else if (PRESETN && req_on && m_cr > 0 && $urandom % 100 < p_req &&
               !(cap && int'(dut.u_core.ctags_out) + mq.size() >= 8)) begin
    la_valid = 1; m_cr--; n_req++;
    if ($urandom % 100 < 75) begin : b_hit             // mostly an entry's StreamID and page
      int i;
      i = $urandom % 8;
      la_sid = e_sid[i]; la_va = e_va[i];
      if (e_ssv[i] && $urandom % 4 != 0) begin la_ssidv = 1; la_ssid = e_ss[i]; end
    end
    mq.push_back(expect_rsp(la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv));
  end
end

always @(negedge PCLK) begin : b_rsp
  logic [35:0] e;
  int k;
  if (PRESETN && lr_valid) begin
    n_rsp++;
    if (mq.size() == 0) fail("LR with no request");
    else begin
      e = mq.pop_front();
      if ({lr_id, lr_resp, lr_pa, lr_attr} !== e)
        fail($sformatf("LR id %h resp %0d pa %h attr %h, expected %h", lr_id, lr_resp, lr_pa, lr_attr, e));
      if (lr_resp == 0) begin
        if (t_out[lr_ctag]) fail($sformatf("tag %0d handed out twice", lr_ctag));
        t_out[lr_ctag] = 1; t_due[lr_ctag] = now + 1 + $urandom % 12;
      end
    end
  end
  lc_valid = 0; lc_ctag = $urandom; k = -1;
  for (int i = 0; i < 8; i++) if (t_out[i] && t_due[i] <= now && k < 0) k = i;
  if (PRESETN && bad_lc) begin
    bad_lc = 0;
    for (int i = 0; i < 8; i++) if (!t_out[i]) k = i;
    lc_valid = 1; lc_ctag = k;
  end else if (PRESETN && !hold && k >= 0 && $urandom % 2) begin
    lc_valid = 1; lc_ctag = k; t_out[k] = 0;
  end
end

task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

// entry i through TBL0..TBL2
task automatic tbl(input int i, input bit v, input logic [7:0] sid, input bit ssv, input logic [7:0] ss,
                   input logic [19:0] va, input logic [19:0] pa, input logic [3:0] pm, input logic [7:0] at);
  wr(A_TBL0, {7'd0, pm, v, 3'(i), ssv, ss, sid});
  wr(A_TBL1, {4'd0, at, va});
  wr(A_TBL2, {12'd0, pa});
  e_v[i] = v; e_sid[i] = sid; e_ssv[i] = ssv; e_ss[i] = ss; e_va[i] = va; e_pa[i] = pa; e_pm[i] = pm; e_attr[i] = at;
endtask
task automatic tbl_rnd(input int i);
  tbl(i, $urandom % 6 != 0, $urandom, $urandom % 2, $urandom, $urandom, $urandom, $urandom, $urandom);
endtask
task automatic inv(input bit all, input logic [7:0] sid);
  wr(A_INV, {23'd0, sid, all});
endtask
task automatic inv_model(input bit all, input logic [7:0] sid);
  for (int i = 0; i < 8; i++) if (all || e_sid[i] == sid) e_v[i] = 0;
endtask
task automatic drain(input string ph);
  int t;
  t = 0;
  while ((mq.size() != 0 || dut.u_core.ctags_out != 0) && t < 5000) begin cycles(1); t++; end
  if (t == 5000) fail($sformatf("%s: stuck", ph));
endtask
task automatic burst(input int n);
  req_on = 1;
  cycles(n);
  req_on = 0;
  drain("burst");
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // a request before the link is open: PROTO
  nocrd = 1;
  irq_expect(IRQ_PROTO);
  // TBL registers: every bit set and cleared (entries written invalid)
  wr(A_TBL0, 32'hFFFF_FFFF); rd_exp(A_TBL0, 32'h01FF_FFFF);
  wr(A_TBL1, 32'hFFFF_FFFF); rd_exp(A_TBL1, 32'h0FFF_FFFF);
  wr(A_TBL0, 32'h01EF_FFFF);                               // cfg_v clear
  wr(A_TBL2, 32'hFFFF_FFFF); rd_exp(A_TBL2, 32'h000F_FFFF);
  tbl(7, 0, 0, 0, 0, 0, 0, 0, 0);
  rd_exp(A_TBL0, 32'h000E_0000); rd_exp(A_TBL1, 0); rd_exp(A_TBL2, 0);
  // the table: every permission and substream kind, full-width values
  for (int i = 0; i < 8; i++)
    tbl(i, 1, $urandom, i >= 4, $urandom, $urandom, $urandom, i < 3 ? 4'hF : 4'($urandom), $urandom);
  // a second entry for the same page and StreamID: the lower one is used
  tbl(5, 1, e_sid[2], 0, 0, e_va[2], 20'hA5A5A, 4'hF, 8'h5A);
  lm_open_req = 1;
  while (!lm_open_ack) cycles(1);
  cycles(8);
  if (m_cr != 4) fail($sformatf("%0d credits after open", m_cr));
  burst(300);
  irq_expect(IRQ_FAULT);
  // rewritten between bursts
  for (int k = 0; k < 12; k++) begin
    for (int j = 0; j < 3; j++) tbl_rnd($urandom % 8);
    burst(60);
  end
  // the PA and attributes returned: every bit both ways
  for (int i = 0; i < 8; i++) tbl(i, 1, 8'(i), 0, 0, 20'(i), 20'hFFFFF, 4'hF, 8'hFF);
  burst(80);
  for (int i = 0; i < 8; i++) tbl(i, 1, 8'(i), 0, 0, 20'(i), 20'h00000, 4'hF, 8'h00);
  burst(80);
  // invalidations with no tag out: synchronized at once (StreamIDs no entry has)
  inv(0, 8'hFF); inv_model(0, 8'hFF);
  irq_expect(IRQ_SYNC);
  inv(0, 8'h80); inv_model(0, 8'h80);
  irq_expect(IRQ_INV_DONE);
  irq_expect(IRQ_SYNC);
  // every tag out, then invalidations: one taken, one held, one dropped
  for (int i = 0; i < 8; i++) tbl(i, 1, 8'(i), 0, 0, 20'(i), $urandom, 4'hF, $urandom);
  hold = 1; cap = 1; req_on = 1;
  while (dut.u_core.ctags_out != 8) cycles(1);
  req_on = 0; cap = 0;
  while (mq.size() != 0) cycles(1);
  rd_exp(A_STATUS, 8);
  inv(0, 8'd3); inv_model(0, 8'd3);
  irq_expect(IRQ_INV_DONE);
  inv(1, 8'd0); inv_model(1, 8'd0);
  rd_exp(A_FLAGS, 32'(1) << FLAG_INV_FULL);
  inv(0, 8'hFF);
  irq_expect(IRQ_INV_OVF);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_SYNC]) fail("SYNC with every tag still out");
  n_sync = 0;
  hold = 0;
  // the first synchronizes once the tags come back; the held one is taken
  // then and synchronizes at once (no tag out)
  poll(A_FLAGS, 32'(1) << FLAG_INV_FULL, 0, 200);
  cycles(3);
  if (n_sync != 2) fail($sformatf("%0d synchronizations, expected 2", n_sync));
  irq_expect(IRQ_SYNC);
  irq_expect(IRQ_INV_DONE);
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  // the table is empty: every request faults
  burst(40);
  // a tag returned that is not out
  bad_lc = 1;
  irq_expect(IRQ_PROTO);
  // close and open again
  lm_open_req = 0;
  while (lm_open_ack) cycles(1);
  m_cr = 0;
  cycles(3);
  for (int i = 0; i < 8; i++) tbl_rnd(i);
  lm_open_req = 1;
  while (!lm_open_ack) cycles(1);
  burst(100);
  // every event again with the interrupts masked, left pending into reset
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, 0);
  for (int i = 0; i < 8; i++) tbl(i, i != 7, 8'(i), 0, 0, 20'(i), $urandom, i == 6 ? 4'h0 : 4'hF, $urandom);
  hold = 1; cap = 1; req_on = 1;
  cycles(60);
  req_on = 0; cap = 0;
  while (mq.size() != 0) cycles(1);
  if (dut.u_core.ctags_out == 0) fail("no tag out");
  inv(0, 8'h20); inv_model(0, 8'h20);
  inv(0, 8'h20);
  inv(0, 8'h20);
  hold = 0;
  drain("masked");
  bad_lc = 1;
  poll(A_FLAGS, 32'(1) << FLAG_INV_FULL, 0, 200);
  cycles(3);
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  if (irq) fail("irq with every interrupt masked");
  lm_open_req = 0;
  while (lm_open_ack) cycles(1);
  m_cr = 0;
  if (n_rsp != n_req) fail($sformatf("%0d requests, %0d responses", n_req, n_rsp));
  $display("LTI: %0d requests answered", n_rsp);
endtask
