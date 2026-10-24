// SPDX-License-Identifier: Apache-2.0
// OCP_IP_Open_Core_Protocol-specific part of tb/OCP_IP_Open_Core_Protocol_apb_tb.sv.
// The TB is the OCP slave on the master pins: a memory, SCmdAccept with
// random delays (or never, for the timeout), read beats spaced so software
// can collect them through RESP (or back to back, to overflow RESP),
// SResp FAIL / ERR on chosen beats, SRespLast on the last beat, early or
// not at all. Software issues transactions through REQ and reads every
// response beat through RESP. Checked: each command (MCmd, MAddr,
// MBurstLength) and write beat (MData) against what software asked for,
// each RESP beat against the slave's memory and responses.
// Covered through the registers: single words and bursts of 1 to 8, posted
// writes, burst length 0 and above 8, REQ written while full (dropped),
// REQ_DONE, RESP_AVAIL, RESP_OVF, ERR (held by the core until reset),
// every interrupt masked and left pending into reset.
initial begin SCmdAccept = 0; SResp = 0; SData = 0; SRespLast = 0; end
// ---------------- OCP slave ----------------
logic [31:0] smem [0:255];
initial for (int i = 0; i < 256; i++) smem[i] = $urandom;
int  acc_pct = 60;                                       // SCmdAccept probability
bit  acc_off = 0;                                        // never accept: timeout
int  rgap = 40;                                          // clocks before each read beat
int  bad_beat = -1;                                      // this read beat answers bad_resp
logic [1:0] bad_resp = 2'd3;
int  lastmode = 0;                                       // SRespLast: 0 last beat, 1 a beat early, 2 never
bit  wr_bad = 0;                                         // write completions answer ERR
logic [39:0] cexp [$];                                   // commands due {MCmd, MBurstLength, MAddr}
logic [31:0] wexp [$];                                   // write beats due
logic [31:0] jaddr [$];
int  jlen [$], jkind [$];                                // jobs: 0 read, 1 write completion
int  wbeat = 0;
always @(negedge PCLK) SCmdAccept = PRESETN && !acc_off && MCmd != 0 && $urandom % 100 < acc_pct;
always @(posedge PCLK) if (PRESETN && MCmd != 0 && SCmdAccept) begin
  if (MByteEn !== 4'hF || MBurstSeq !== 0) fail("MByteEn / MBurstSeq not full-word INCR");
  if (MCmd == 3'd2 || wbeat == 0) begin
    if (cexp.size() == 0) fail("a command never asked for");
    else begin
      if ({MCmd, MBurstLength, MAddr} !== cexp[0]) fail($sformatf("command %h, expected %h", {MCmd, MBurstLength, MAddr}, cexp[0]));
      void'(cexp.pop_front());
    end
  end
  if (MCmd == 3'd2) begin jaddr.push_back(MAddr); jlen.push_back(MBurstLength); jkind.push_back(0); end
  else begin
    if (wexp.size() == 0 || MData !== wexp[0]) fail($sformatf("write beat %h unexpected", MData));
    if (wexp.size() != 0) void'(wexp.pop_front());
    smem[8'(MAddr[9:2] + 8'(wbeat))] = MData;
    wbeat++;
    if (wbeat == int'(MBurstLength)) begin
      wbeat = 0;
      if (MCmd == 3'd5) begin jaddr.push_back(MAddr); jlen.push_back(1); jkind.push_back(1); end
    end
  end
end
// responses: read beats (all but one when SRespLast comes early), write completions
initial forever begin
  @(negedge PCLK);
  if (jkind.size() != 0) begin : b_job
    int k, n;
    logic [31:0] a;
    k = jkind.pop_front(); n = jlen.pop_front(); a = jaddr.pop_front();
    if (k == 0 && lastmode == 1 && n > 1) n--;
    for (int i = 0; i < n; i++) begin
      repeat (rgap) @(negedge PCLK);
      SResp = i == bad_beat && k == 0 || k == 1 && wr_bad ? bad_resp : 2'd1;
      SData = k == 0 ? smem[8'(a[9:2] + 8'(i))] : $urandom;
      SRespLast = lastmode == 2 ? 1'b0 : i == n - 1;
      @(negedge PCLK);
      SResp = 0; SData = $urandom; SRespLast = 0;
    end
  end
end
// ---------------- software ----------------
logic [32:0] rexp [$];                                   // RESP beats due {err, data}
function automatic int nlen(input logic [4:0] len); return len == 0 ? 1 : len > 8 ? 8 : int'(len); endfunction
// commit REQ and wait for the core to take it
task automatic commit(input logic [31:0] a, input logic [31:0] d, input logic [6:0] ctl);
  wr(A_REQ0, a); wr(A_REQ1, d); wr(A_REQ2, 32'(ctl));
  poll(A_FLAGS, 32'(1) << FLAG_REQ_FULL, 0, 400);
endtask
// a transaction; acc: the slave will take it (else it times out)
task automatic txn(input bit rw, input bit posted, input logic [31:0] a, input logic [4:0] len, input bit acc = 1);
  int n;
  logic [31:0] d;
  n = nlen(len);
  if (acc) cexp.push_back({rw ? (posted ? 3'd1 : 3'd5) : 3'd2, 5'(n), a});
  for (int k = 0; k < (rw ? n : 1); k++) begin
    d = $urandom;
    if (rw && acc) wexp.push_back(d);
    commit(k == 0 ? a : $urandom, d, {len, posted, rw});
  end
  if (!acc) rexp.push_back({1'b1, 32'h0});
  else if (rw) rexp.push_back({!posted && wr_bad, 32'h0});
endtask
// collect the n beats of a read from a
task automatic collect_rd(input logic [31:0] a, input int n);
  for (int i = 0; i < n; i++) begin
    poll(A_FLAGS, 32'(1) << FLAG_RESP_AVAIL, 32'(1) << FLAG_RESP_AVAIL, 400);
    rd(A_RESP0);
    if (rdv !== smem[8'(a[9:2] + 8'(i))]) fail($sformatf("RESP read beat %0d = %h, expected %h", i, rdv, smem[8'(a[9:2] + 8'(i))]));
    rd_exp(A_RESP1, i == bad_beat);
  end
endtask
task automatic collect;
  logic [32:0] e;
  while (rexp.size() != 0) begin
    e = rexp.pop_front();
    poll(A_FLAGS, 32'(1) << FLAG_RESP_AVAIL, 32'(1) << FLAG_RESP_AVAIL, 400);
    rd_exp(A_RESP0, e[31:0]);
    rd_exp(A_RESP1, 32'(e[32]));
  end
endtask
task automatic read(input logic [31:0] a, input logic [4:0] len);
  int n;
  n = nlen(len);
  txn(0, 0, a, len);
  collect_rd(a, lastmode == 1 && n > 1 ? n - 1 : n);
endtask
task automatic write(input bit posted, input logic [31:0] a, input logic [4:0] len);
  txn(1, posted, a, len);
  collect();
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_RESP0, 0); rd_exp(A_RESP1, 0);                // empty
  wr(A_IRQ_ENABLE, IRQ_ALL);
  write(0, 32'h100, 1);
  irq_expect(IRQ_REQ_DONE);
  irq_expect(IRQ_RESP_AVAIL);
  read(32'h100, 1);
  // bursts of every length, both write kinds, all address and data bits
  for (int k = 0; k < 24; k++) begin
    write(k % 3 == 0, {$urandom} & 32'hFFFF_FFFC, 5'(k % 9));
    read({$urandom} & 32'hFFFF_FFFC, 5'((k + 4) % 9));
  end
  begin : b_ones
    logic [31:0] a;
    a = 32'hFFFF_FFFC;
    smem[8'(a[9:2])] = 32'hFFFF_FFFF; read(a, 1);
    smem[8'(a[9:2])] = 32'h0;         read(a, 1);
  end
  // addresses not word aligned pass through as given
  write(0, 32'h0000_0103, 1); read(32'h0000_0101, 2); read(32'h0000_0102, 1);
  // RESP read in the clock a beat is captured (beats spaced 2 to 9 clocks,
  // RESP1 read back to back; data not checked here)
  for (int g = 2; g < 10; g++) begin
    rgap = g;
    txn(0, 0, 32'h0, 6);
    repeat (14) rd(A_RESP1);
    cycles(40);
    rd(A_FLAGS);
    while (rdv[FLAG_RESP_AVAIL]) begin rd(A_RESP1); rd(A_FLAGS); end
  end
  rgap = 40;
  // SRespLast early and never
  lastmode = 1; read(32'h40, 4); read(32'h40, 1);
  lastmode = 2; read(32'h40, 3);
  lastmode = 0;
  // RESP overflow: beats back to back, only the first kept
  wr(A_IRQ_STATUS, IRQ_ALL);
  rgap = 0;
  txn(0, 0, 32'h80, 4);
  cycles(20);
  irq_expect(IRQ_RESP_OVF);
  rd_exp(A_RESP0, smem[32]); rd_exp(A_RESP1, 0);
  rgap = 40;
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_RESP_AVAIL | 32'(1) << IRQ_REQ_DONE);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // errors (ERR is then held until reset): a FAIL read beat, an ERR write
  // completion, a burst above 8, a timeout with REQ written while full
  bad_beat = 1; bad_resp = 2'd2; read(32'hC0, 3);
  bad_beat = -1;
  wr_bad = 1; write(0, 32'h20, 2); wr_bad = 0;
  bad_resp = 2'd3; bad_beat = 0; read(32'h20, 1); bad_beat = -1;
  write(0, 32'h0, 5'd31);
  read(32'h0, 5'd16);
  acc_off = 1;
  txn(0, 0, 32'h44, 1, 0);
  wr(A_REQ0, 32'h48); wr(A_REQ1, 0); wr(A_REQ2, {5'd1, 1'b0, 1'b0});   // held: the core is busy
  rd_exp(A_FLAGS, 32'(1) << FLAG_REQ_FULL);
  wr(A_REQ2, 0);                                         // dropped
  irq_expect(IRQ_REQ_OVF);
  collect();                                             // the timeout
  acc_off = 0;
  cexp.push_back({3'd2, 5'd1, 32'h48});
  collect_rd(32'h48, 1);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERR]) fail("ERR not set");
  // masked: every event again, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  acc_off = 1;
  txn(0, 0, 32'h44, 1, 0);
  wr(A_REQ0, 32'h48); wr(A_REQ1, 0); wr(A_REQ2, {5'd1, 1'b0, 1'b0});
  wr(A_REQ2, 0);
  collect();
  rgap = 0; acc_off = 0;
  cexp.push_back({3'd2, 5'd1, 32'h48});
  cycles(80);
  wr(A_REQ0, 32'h4C); wr(A_REQ1, 0); wr(A_REQ2, {5'd2, 1'b0, 1'b0});
  cexp.push_back({3'd2, 5'd2, 32'h4C});
  cycles(80);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
