// SPDX-License-Identifier: Apache-2.0
// CHI-specific part of tb/CHI_apb_tb.sv. A small home node model sits on
// the link channels: it counts the L-Credits the node grants, sends REQ
// and write data flits with them, grants TXRSP and TXDAT credits, and
// collects the responses.
// Covered through the registers: requests served without an error leave
// IRQ_STATUS clear, a DERR read and an NDERR request set ERR, a flit sent
// without a credit and write data not expected set PROTO, every interrupt
// bit masked, raising irq and cleared.
localparam int LN = 16;

// ---------------- home node ----------------
int          h_rq = 0, h_dc = 0;                 // credits held for RXREQ / RXDAT
int          h_rc = 0, h_tc = 0;                 // credits given for TXRSP / TXDAT
bit          stop_tc = 0;
logic [28:0] h_rsp [$];
logic [146:0] h_dat [$];
initial begin
  rxreqflitv = 0; rxreqflit = 0; rxdatflitv = 0; rxdatflit = 0; txrsplcrdv = 0; txdatlcrdv = 0;
end
always @(posedge PCLK) begin
  if (!PRESETN) begin h_rq = 0; h_dc = 0; h_rc = 0; h_tc = 0; end
  else begin
    if (rxreqlcrdv) h_rq++;
    if (rxdatlcrdv) h_dc++;
    if (txrspflitv) begin
      h_rsp.push_back(txrspflit);
      if (h_rc == 0) fail("TXRSP flit without a credit");
      h_rc--;
    end
    if (txdatflitv) begin
      h_dat.push_back(txdatflit);
      if (h_tc == 0) fail("TXDAT flit without a credit");
      h_tc--;
    end
    if (txrsplcrdv) h_rc++;
    if (txdatlcrdv) h_tc++;
  end
end
always @(negedge PCLK) begin
  txrsplcrdv = PRESETN && h_rc < 15 && $urandom % 2 == 0;
  txdatlcrdv = PRESETN && !stop_tc && h_tc < 15 && $urandom % 2 == 0;
end

task automatic c_req(input logic [5:0] op, input logic [7:0] txn, input logic ord,
                     input logic [2:0] size, input logic [15:0] addr, input bit crd);
  @(negedge PCLK);
  s_of[txn] = $urandom;
  if (crd) begin
    while (h_rq == 0) @(negedge PCLK);
    h_rq--;
  end
  rxreqflitv = 1;
  rxreqflit = {s_of[txn], txn, op, ord, size, addr};
  @(negedge PCLK);
  rxreqflitv = 0;
  rxreqflit = {$urandom, $urandom};               // noise between flits
endtask
task automatic c_dat(input logic [7:0] dbid, input logic [3:0] op, input logic [1:0] id,
                     input logic [15:0] be, input logic [127:0] d, input bit crd);
  @(negedge PCLK);
  if (crd) begin
    while (h_dc == 0) @(negedge PCLK);
    h_dc--;
  end
  rxdatflitv = 1;
  rxdatflit = {dbid, op, id, be, d};
  @(negedge PCLK);
  rxdatflitv = 0;
  rxdatflit = {$urandom, $urandom, $urandom, $urandom, $urandom};
endtask
// the next response; checks its TxnID, opcode and RespErr, returns its DBID
logic [6:0] s_of [0:255];                       // SrcID of each TxnID
logic [7:0] h_dbid;
logic [28:0] x_rsp;
logic [146:0] x_dat;
task automatic c_rsp(input logic [7:0] txn, input logic [3:0] op, input logic [1:0] err);
  int n = 0;
  while (h_rsp.size() == 0 && n < 500) begin @(negedge PCLK); n++; end
  if (h_rsp.size() == 0) fail("no response");
  else begin
    x_rsp = h_rsp.pop_front();
    h_dbid = x_rsp[7:0];
    if (x_rsp[28:8] != {s_of[txn], txn, op, err})
      fail($sformatf("RSP %h, expected TxnID %h opcode %h RespErr %0d", x_rsp, txn, op, err));
  end
endtask
// the next data beat
task automatic c_cd(input logic [7:0] txn, input logic [1:0] id, input logic [1:0] err, input logic [127:0] d);
  int n = 0;
  while (h_dat.size() == 0 && n < 500) begin @(negedge PCLK); n++; end
  if (h_dat.size() == 0) fail("no CompData");
  else begin
    if (h_dat[0] != {s_of[txn], txn, err, id, d})
      fail($sformatf("CompData %h, expected TxnID %h DataID %0d RespErr %0d data %h", h_dat[0], txn, id, err, d));
    void'(h_dat.pop_front());
  end
endtask
task automatic irq_expect(input int b, input bit v);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (rdv[b] !== v) fail($sformatf("IRQ bit %0d is %0d (%h)", b, rdv[b], rdv));
endtask

logic [127:0] cd [0:3];
logic [7:0]   dbid0;
task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_FLAGS, 0);                              // no streams: always 0
  // WriteNoSnpFull of line 1, read back with Order: no error
  for (int i = 0; i < 4; i++) cd[i] = {$urandom, $urandom, $urandom, $urandom};
  // and, while it waits for data, WriteNoSnpPtl of half a beat (the
  // second write buffer): DBIDResp, then Comp
  c_req(6'h1D, 8'h10, 0, 6, 16'h0040, 1);
  c_rsp(8'h10, 4'h5, 0);
  dbid0 = h_dbid;
  c_req(6'h1C, 8'h12, 0, 4, 16'h0090, 1);
  c_rsp(8'h12, 4'h6, 0);
  if (dbid0 != 8'h10 || h_dbid != 8'h92) fail($sformatf("DBIDs %h %h", dbid0, h_dbid));
  for (int i = 0; i < 4; i++) c_dat(dbid0, 4'h3, 2'(i), 16'hFFFF, cd[i], 1);
  c_dat(h_dbid, 4'h3, 1, 16'h00FF, {64'h0, 64'h0123_4567_89AB_CDEF}, 1);
  c_rsp(8'h12, 4'h4, 0);
  c_req(6'h04, 8'h11, 1, 6, 16'h0040, 1);
  c_rsp(8'h11, 4'h8, 0);
  for (int i = 0; i < 4; i++) c_cd(8'h11, 2'(i), 0, cd[i]);
  c_req(6'h04, 8'h13, 0, 4, 16'h0090, 1);
  c_cd(8'h13, 1, 0, {64'h0, 64'h0123_4567_89AB_CDEF});
  // random TxnIDs and SrcIDs: a beat written, read back with Order
  for (int i = 0; i < 24; i++) begin : b_rnd
    logic [7:0]   t;
    logic [15:0]  a;
    logic [127:0] d;
    t = $urandom; a = 16'($urandom % 1024); d = {$urandom, $urandom, $urandom, $urandom};
    c_req(6'h1C, t, 0, 4, a, 1);
    c_rsp(t, 4'h6, 0);
    if (h_dbid != {1'b0, t[6:0]}) fail($sformatf("DBID %h for TxnID %h", h_dbid, t));
    c_dat(h_dbid, 4'h3, a[5:4], 16'hFFFF, d, 1);
    c_rsp(t, 4'h4, 0);
    t = $urandom;
    c_req(6'h04, t, 1, 4, a, 1);
    c_rsp(t, 4'h8, 0);
    c_cd(t, a[5:4], 0, d);
  end
  irq_expect(IRQ_ERR, 0);
  irq_expect(IRQ_PROTO, 0);
  // ReadNoSnp beyond the memory: DERR
  c_req(6'h04, 8'h14, 0, 4, 16'h0400, 1);
  c_cd(8'h14, 0, 2'b10, 0);
  irq_expect(IRQ_ERR, 1);
  wr(A_IRQ_STATUS, 1 << IRQ_ERR);
  irq_expect(IRQ_ERR, 0);
  // an opcode not supported: Comp NDERR
  c_req(6'h0A, 8'h15, 0, 6, 16'h0000, 1);
  c_rsp(8'h15, 4'h4, 2'b11);
  irq_expect(IRQ_ERR, 1);
  // write data nobody waits for, then a REQ without a credit
  c_dat(8'h7F, 4'h3, 0, 16'hFFFF, 0, 1);
  irq_expect(IRQ_PROTO, 1);
  wr(A_IRQ_STATUS, 1 << IRQ_PROTO);
  irq_expect(IRQ_PROTO, 0);
  // TXDAT credits held back: reads fill the request slots, the node stops
  // granting REQ credits, and one more REQ comes without a credit
  stop_tc = 1;
  while (h_tc != 0) begin c_req(6'h04, 8'h20, 0, 6, 16'h0000, 1); cycles(8); end
  while (h_rq != 0) begin c_req(6'h04, 8'h21, 0, 6, 16'h0000, 1); cycles(8); end
  cycles(30);
  if (h_rq != 0) fail("REQ credits granted with every slot taken");
  c_req(6'h04, 8'h16, 0, 0, 16'h0000, 0);
  irq_expect(IRQ_PROTO, 1);
  stop_tc = 0;
  cycles(300);
  if (h_rsp.size() != 0) fail("a response to a read without Order");
  for (int i = h_dat.size(); i > 0; i--) begin
    x_dat = h_dat.pop_front();
    if (x_dat[139:132] == 8'h16) fail("CompData for the dropped REQ");
  end

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[1:0] != 2'b11) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 2; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[1:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
  c_req(6'h04, 8'h17, 0, 7, 16'h0000, 1);
  c_cd(8'h17, 0, 2'b11, 0);
  cycles(3);
  if (!irq) fail("irq low with ERR pending");
  wr(A_IRQ_ENABLE, 0);
endtask
