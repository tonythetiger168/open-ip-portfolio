// SPDX-License-Identifier: Apache-2.0
// NVMe-specific part of tb/NVMe_apb_tb.sv. A host memory model answers the
// core's memory master (random back-pressure, in-order read data); the
// host driver builds queue entries in it and works the controller through
// the registers.
// Covered through the registers: CC and QBASE (queues moved), the SQ and
// CQ doorbells (valid, out of range, while off), CSTS (ready, SQ head, CQ
// tail), Write / Read / Flush with data checked, every error status, the
// phase tag across a CQ wrap, the CQ full, CC cleared mid-command (abort),
// each interrupt.
localparam int QD = 8, NBLK = 8, BLKDW = 4, ND = NBLK * BLKDW;

// ---------------- host memory ----------------
logic [31:0] hm [0:65535];
logic [31:0] rs_d [$];
int          h_slow = 0;                       // % of clocks the memory stalls
always @(posedge PCLK) begin
  if (!PRESETN) rs_d.delete();
  else begin
    if (m_rsp_valid) void'(rs_d.pop_front());
    if (m_req_valid && m_req_ready) begin
      if (m_req_we) hm[m_req_addr] = m_req_wdata;
      else rs_d.push_back(hm[m_req_addr]);
    end
  end
end
always @(negedge PCLK) begin
  m_req_ready = $urandom % 100 >= h_slow;
  m_rsp_valid = rs_d.size() != 0 && $urandom % 100 >= h_slow;
  m_rsp_data = m_rsp_valid ? rs_d[0] : $urandom;
end

// ---------------- host ----------------
logic [15:0] sqb, cqb;
int          tail, head, n_sub;
bit          cph;
logic [31:0] nm [0:ND-1];
logic [15:0] e_cid [$];
logic [7:0]  e_sc [$];
int          e_buf [$], e_n [$], e_slba [$];
bit          e_rd [$];

task automatic h_enable(input logic [15:0] sb, input logic [15:0] cb);
  wr(A_CC, 0);
  poll(A_CSTS, 32'h1, 32'h0, 200);
  sqb = sb; cqb = cb;
  wr(A_QBASE, {cb, sb});
  for (int i = 0; i < QD * 4; i++) hm[(cb + i) % 65536] = 0;
  wr(A_CC, 1);
  poll(A_CSTS, 32'h7F, 32'h1, 20);
  tail = 0; head = 0; cph = 1;
endtask

// write a command at the SQ tail (not rung); returns the expected status
task automatic h_put(input logic [7:0] op, input logic [3:0] fp, input logic [31:0] nsid, input logic [1:0] poff,
                     input logic [31:0] phi, input logic [31:0] slo, input logic [31:0] shi, input logic [15:0] nlb,
                     input int buf_at);
  logic [31:0] e [0:15];
  logic [7:0]  sc;
  int          n;
  for (int i = 0; i < 16; i++) e[i] = $urandom;
  sc = op > 2 ? 8'h01 : fp != 0 ? 8'h02 : !(nsid == 1 || op == 0 && nsid == 32'hFFFFFFFF) ? 8'h0B :
       op != 0 && poff != 0 ? 8'h13 : op != 0 && !(shi == 0 && slo < NBLK && nlb < NBLK && slo + nlb < NBLK) ? 8'h80 :
       op != 0 && phi != 0 ? 8'h04 : 8'h00;
  n = sc == 0 && op != 0 ? (nlb + 1) * BLKDW : 0;
  for (int i = 0; i < n; i++)
    if (op == 1) begin
      hm[buf_at + i] = $urandom;
      nm[slo * BLKDW + i] = hm[buf_at + i];
    end else hm[buf_at + i] = $urandom;
  e[0] = {e[0][31:16], fp[3:2], e[0][13:10], fp[1:0], op};
  e[1] = nsid; e[6] = {14'd0, 16'(buf_at), poff}; e[7] = phi; e[10] = slo; e[11] = shi; e[12] = {e[12][31:16], nlb};
  for (int i = 0; i < 16; i++) hm[(sqb + tail * 16 + i) % 65536] = e[i];
  e_cid.push_back(e[0][31:16]); e_sc.push_back(sc); e_buf.push_back(buf_at); e_n.push_back(n);
  e_slba.push_back(slo); e_rd.push_back(sc == 0 && op == 2);
  tail = (tail + 1) % QD;
  n_sub++;
endtask
// wait for the completion at the CQ head and check it; ring the CQ head
// doorbell when ring is set
task automatic h_get(input bit ring);
  int a, t;
  a = (cqb + head * 4) % 65536;
  t = 0;
  while (hm[a + 3][16] != cph && t < 5000) begin cycles(1); t++; end
  if (t == 5000) fail("no completion");
  else begin
    if (hm[a] != 0 || hm[a + 1] != 0) fail("CQE DW0/DW1 not zero");
    if (hm[a + 3][15:0] != e_cid[0] || hm[a + 3][24:17] != e_sc[0] || hm[a + 3][31] != (e_sc[0] != 0) ||
        hm[a + 3][30:25] != 0 || hm[a + 2][31:16] != 16'd1)
      fail($sformatf("CQE %h %h, expected CID %h SC %h", hm[a + 3], hm[a + 2], e_cid[0], e_sc[0]));
    if (e_rd[0])
      for (int i = 0; i < e_n[0]; i++)
        if (hm[e_buf[0] + i] !== nm[e_slba[0] * BLKDW + i]) fail($sformatf("Read data %0d", i));
  end
  void'(e_cid.pop_front()); void'(e_sc.pop_front()); void'(e_buf.pop_front()); void'(e_n.pop_front());
  void'(e_slba.pop_front()); void'(e_rd.pop_front());
  head = (head + 1) % QD;
  if (head == 0) cph = !cph;
  if (ring) wr(A_CQ_DB, head);
endtask
task automatic h_cmd(input logic [7:0] op, input logic [3:0] fp, input logic [31:0] nsid, input logic [1:0] poff,
                     input logic [31:0] phi, input logic [31:0] slo, input logic [31:0] shi, input logic [15:0] nlb);
  h_put(op, fp, nsid, poff, phi, slo, shi, nlb, 16'h2000 + 64 * (n_sub % 8));
  wr(A_SQ_DB, tail);
  h_get(1);
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  wr(A_IRQ_STATUS, 1 << b);
endtask

task automatic ip_func;
  n_sub = 0;
  for (int i = 0; i < ND; i++) nm[i] = 0;
  for (int i = 0; i < 65536; i++) hm[i] = $urandom;
  wr(A_IRQ_ENABLE, 0);
  // a doorbell while off
  wr(A_SQ_DB, 1);
  irq_expect(IRQ_ERR_DB);
  h_enable(16'h0100, 16'h0400);
  // Write the whole namespace, read it back in parts, flush
  h_cmd(8'h01, 0, 1, 0, 0, 0, 0, NBLK - 1);
  irq_expect(IRQ_CQE);
  h_cmd(8'h02, 0, 1, 0, 0, 0, 0, NBLK - 1);
  h_cmd(8'h02, 0, 1, 0, 0, 3, 0, 1);
  h_cmd(8'h01, 0, 1, 0, 0, 5, 0, 0);
  h_cmd(8'h02, 0, 1, 0, 0, 4, 0, 3);
  h_cmd(8'h00, 0, 1, 0, 0, 0, 0, 0);
  h_cmd(8'h00, 0, 32'hFFFFFFFF, 0, 0, 0, 0, 0);
  // every error status
  h_cmd(8'h05, 0, 1, 0, 0, 0, 0, 0);
  irq_expect(IRQ_ERR_CMD);
  h_cmd(8'h01, 4'b0001, 1, 0, 0, 0, 0, 0);
  h_cmd(8'h02, 4'b1000, 1, 0, 0, 0, 0, 0);
  h_cmd(8'h02, 0, 2, 0, 0, 0, 0, 0);
  h_cmd(8'h01, 0, 32'hFFFFFFFF, 0, 0, 0, 0, 0);
  h_cmd(8'h01, 0, 1, 2'b10, 0, 0, 0, 0);
  h_cmd(8'h02, 0, 1, 0, 0, 6, 0, 2);
  h_cmd(8'h02, 0, 1, 0, 0, 0, 1, 0);
  h_cmd(8'h01, 0, 1, 0, 32'h8000_0000, 0, 0, 0);
  rd(A_CSTS);
  if (rdv[0] !== 1 || rdv[3:1] != 3'(tail) || rdv[6:4] != 3'(tail)) fail($sformatf("CSTS %h after commands", rdv));
  // invalid doorbells
  wr(A_SQ_DB, 32'hFFFF);
  irq_expect(IRQ_ERR_DB);
  wr(A_CQ_DB, 32'hFFFF);
  irq_expect(IRQ_ERR_DB);
  // the CQ fills: seven commands complete without the head doorbell, the
  // eighth waits until it is rung
  h_slow = 30;
  for (int i = 0; i < QD - 1; i++) h_put(8'h01, 0, 1, 0, 0, i, 0, 0, 16'h3000 + 16 * i);
  wr(A_SQ_DB, tail);
  for (int i = 0; i < QD - 1; i++) h_get(0);
  h_put(8'h02, 0, 1, 0, 0, 0, 0, NBLK - 1, 16'h4000);
  wr(A_SQ_DB, tail);
  cycles(200);
  rd(A_CSTS);
  if (rdv[6:4] != 3'(head) || rdv[3:1] != 3'(tail)) fail($sformatf("CSTS %h with the CQ full", rdv));
  wr(A_CQ_DB, head);
  h_get(1);
  // CC cleared in the middle of a Write: the controller stops, its
  // pointers go to zero; the namespace keeps what landed
  h_slow = 85;
  h_put(8'h01, 0, 1, 0, 0, 0, 0, NBLK - 1, 16'h5000);
  wr(A_SQ_DB, tail);
  cycles(30);
  wr(A_CC, 0);
  poll(A_CSTS, 32'h7F, 32'h0, 400);
  for (int i = 0; i < ND; i++) nm[i] = dut.u_core.mem[i];
  e_cid.delete(); e_sc.delete(); e_buf.delete(); e_n.delete(); e_slba.delete(); e_rd.delete();
  h_slow = 10;
  // queues moved
  h_enable(16'hF000, 16'hEFC0);
  for (int i = 0; i < 12; i++) h_cmd($urandom % 2 ? 8'h01 : 8'h02, 0, 1, 0, 0, i % NBLK, 0, 0);
  h_enable(16'h0FF0, 16'h7FF8);
  h_cmd(8'h02, 0, 1, 0, 0, 0, 0, NBLK - 1);
  wr(A_CC, 0);
  poll(A_CSTS, 32'h1, 32'h0, 20);

  // interrupts: masked, raising irq, cleared one by one
  wr(A_SQ_DB, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  h_enable(16'h0100, 16'h0400);
  h_cmd(8'h03, 0, 1, 0, 0, 0, 0, 0);
  wr(A_CC, 0);
  poll(A_CSTS, 32'h1, 32'h0, 20);
  wr(A_CQ_DB, 0);
  rd(A_FLAGS);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (rdv[2:0] != 3'h7) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 3; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[2:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  wr(A_IRQ_ENABLE, 1 << IRQ_ERR_DB);
  wr(A_SQ_DB, 3);
  cycles(3);
  if (!irq) fail("irq low with ERR_DB pending");
  wr(A_IRQ_ENABLE, 0);
endtask
